package com.oviewer.oviewer

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
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
class SponsorBridgeTest {
    private class Result : MethodChannel.Result {
        var value: Any? = null
        var completions = 0
        override fun success(result: Any?) { value = result; completions++ }
        override fun error(code: String, message: String?, details: Any?) { value = code }
        override fun notImplemented() { value = "notImplemented" }
    }
    @Test fun opensOnlySelectedInstalledApp() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val bridge = SponsorBridge(activity)
        for ((key, pkg) in listOf("wechat" to "com.tencent.mm", "alipay" to "com.eg.android.AlipayGphone")) {
            val info = ResolveInfo().apply {
                activityInfo = ActivityInfo().apply {
                    packageName = pkg; name = "$pkg.Main"; exported = true; enabled = true
                    applicationInfo = ApplicationInfo().apply { packageName = pkg }
                }
            }
            val launch = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER).setPackage(pkg)
            Shadows.shadowOf(activity.packageManager).addResolveInfoForIntent(launch, info)
            val result = Result()
            bridge.onMethodCall(MethodCall("openApp", key), result)
            assertEquals(true, result.value)
            assertEquals(pkg, Shadows.shadowOf(activity).nextStartedActivity.component!!.packageName)
        }
        bridge.dispose()
    }
    @Test fun unknownOrMissingAppDoesNotLaunch() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val bridge = SponsorBridge(activity)
        for (key in listOf("wechat", "alipay", "https://example.com")) {
            val result = Result()
            bridge.onMethodCall(MethodCall("openApp", key), result)
            assertEquals(false, result.value)
            assertNull(Shadows.shadowOf(activity).nextStartedActivity)
        }
        bridge.dispose()
    }
    @Test fun savesBothCodesThroughOnePermissionPromptAndCompletesIndependently() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val scans = mutableListOf<(Boolean) -> Unit>()
        val files = mutableListOf<File>()
        val exporter = PageImageExporter(activity, Executor { it.run() }, allowConcurrent = true,
            permissionRequest = 7315, namePattern = Regex("OViewer_sponsor_.*"), scan = { file, _, done ->
                files.add(file); scans.add(done)
            })
        val results = mutableListOf<Result>()
        for ((index, kind) in listOf("wechat", "alipay").withIndex()) {
            val file = File(activity.cacheDir, "sponsor-$kind.png"); file.writeBytes(byteArrayOf(1, 2, index.toByte()))
            val result = Result(); results.add(result)
            exporter.onMethodCall(MethodCall("saveImage", mapOf("path" to file.path,
                "name" to "OViewer_sponsor_${kind}_100.png", "mime" to "image/png")), result)
            assertNull(result.value)
        }
        exporter.permissionResult(7315, intArrayOf(PackageManager.PERMISSION_GRANTED))
        assertEquals(2, scans.size)
        scans[1](true)
        assertEquals("saved", results[1].value)
        assertNull(results[0].value)
        scans[0](false)
        assertEquals("save_failed", results[0].value)
        assertFalse(files[0].exists())
        assertTrue(files[1].exists())
        assertEquals(1, results[0].completions)
        assertEquals(1, results[1].completions)
        files[1].delete(); exporter.dispose()
    }
    @Test fun permissionDenialFinishesBothSavesWithoutBlockingAppLaunch() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val exporter = PageImageExporter(activity, Executor { it.run() }, allowConcurrent = true,
            permissionRequest = 7315, namePattern = Regex("OViewer_sponsor_.*"))
        val results = (0..1).map { index ->
            val file = File(activity.cacheDir, "denied-$index.png"); file.writeBytes(byteArrayOf(1))
            Result().also { exporter.onMethodCall(MethodCall("saveImage", mapOf("path" to file.path,
                "name" to "OViewer_sponsor_${index}.png", "mime" to "image/png")), it) }
        }
        exporter.permissionResult(7315, intArrayOf(PackageManager.PERMISSION_DENIED))
        results.forEach { assertEquals("permission_denied", it.value); assertEquals(1, it.completions) }
        exporter.dispose()
    }
}
