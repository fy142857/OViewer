package com.oviewer.oviewer

import android.app.Activity
import android.content.Intent
import android.content.ActivityNotFoundException
import android.content.pm.PackageInfo
import android.content.pm.Signature
import android.content.pm.SigningInfo
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

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [21, 26, 28, 35])
class ApkUpdateBridgeTest {
    class NoSettingsActivity : Activity() {
        override fun startActivity(intent: Intent) { throw ActivityNotFoundException() }
    }
    private val cert = "b".repeat(64)
    private fun info(code: Int, version: String = "1.8.0", name: String = "com.oviewer.oviewer") = PackageInfo().apply {
        packageName = name; versionName = version; versionCode = code
    }

    private class Result : MethodChannel.Result {
        var value: Any? = null
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) { value = code }
        override fun notImplemented() { value = "notImplemented" }
    }

    @Test fun validatesVersionPackageAndPermanentCertificate() {
        val installed = info(67, "1.7.0")
        ApkUpdateBridge.validate(info(70), installed, "1.8.0", 70, cert, setOf(cert), setOf(cert))
        val cases = listOf(
            Pair(info(70, name = "another.app"), "package_mismatch"),
            Pair(info(70, version = "1.9.0"), "version_mismatch"),
            Pair(info(69), "version_mismatch"))
        for ((archive, code) in cases) {
            val failure = assertThrows(Exception::class.java) {
                ApkUpdateBridge.validate(archive, installed, "1.8.0", 70, cert, setOf(cert), setOf(cert))
            }
            assertEquals(code, failure.message)
        }
        assertEquals("not_newer", assertThrows(Exception::class.java) {
            ApkUpdateBridge.validate(info(70), info(71), "1.8.0", 70, cert, setOf(cert), setOf(cert))
        }.message)
        for ((archive, current) in listOf(Pair(emptySet<String>(), setOf(cert)), Pair(setOf(cert), setOf("a".repeat(64))), Pair(setOf(cert, "a".repeat(64)), setOf(cert)))) {
            assertEquals("signature_mismatch", assertThrows(Exception::class.java) {
                ApkUpdateBridge.validate(info(70), installed, "1.8.0", 70, cert, archive, current)
            }.message)
        }
    }

    @Test fun restrictsProviderToOwnedApkAndGrantsReadOnlyAccess() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val folder = File(activity.cacheDir, "updates").apply { mkdirs() }
        val file = File(folder, "package.apk").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        assertEquals(file.canonicalFile, ApkUpdateBridge.packageFile(activity.cacheDir, file.path))
        val intent = ApkUpdateBridge.installIntent(activity, file)
        assertEquals(Intent.ACTION_VIEW, intent.action)
        assertEquals("application/vnd.android.package-archive", intent.type)
        assertEquals("content", intent.data?.scheme)
        assertEquals("${activity.packageName}.apk_updates", intent.data?.authority)
        assertEquals(Intent.FLAG_GRANT_READ_URI_PERMISSION, intent.flags)
        activity.contentResolver.openInputStream(intent.data!!).use { assertEquals(1, it!!.read()) }
        val outside = File(activity.cacheDir, "outside.apk").apply { writeText("outside") }
        assertThrows(IllegalArgumentException::class.java) { ApkUpdateBridge.packageFile(activity.cacheDir, outside.path) }
        assertThrows(IllegalArgumentException::class.java) { ApkUpdateBridge.packageFile(activity.cacheDir, File(folder, "missing.apk").path) }
    }

    @Test fun permissionExplanationIsUserControlled() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val bridge = ApkUpdateBridge(activity)
        val result = Result()
        bridge.onMethodCall(MethodCall("openSettings", mapOf("language" to "en")), result)
        if (android.os.Build.VERSION.SDK_INT < 26) assertEquals(false, result.value)
        else {
            val dialog = org.robolectric.shadows.ShadowAlertDialog.getLatestAlertDialog()
            assertEquals("Allow update installation", Shadows.shadowOf(dialog).title)
            dialog.getButton(android.content.DialogInterface.BUTTON_NEGATIVE).performClick()
        Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
            assertEquals(false, result.value)
            assertNull(Shadows.shadowOf(activity).nextStartedActivity)
        }
        bridge.dispose()
    }

    @Test fun permissionSettingsTargetsOnlyThisPackage() {
        if (android.os.Build.VERSION.SDK_INT < 26) return
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val bridge = ApkUpdateBridge(activity)
        val result = Result()
        bridge.onMethodCall(MethodCall("openSettings", mapOf("language" to "zh")), result)
        org.robolectric.shadows.ShadowAlertDialog.getLatestAlertDialog()
            .getButton(android.content.DialogInterface.BUTTON_POSITIVE).performClick()
        Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        val intent = Shadows.shadowOf(activity).nextStartedActivity
        assertEquals(android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, intent.action)
        assertEquals("package:${activity.packageName}", intent.data.toString())
        assertEquals(true, result.value)
        bridge.dispose()
    }

    @Test fun extractsCurrentSigningCertificateOnOldAndNewApis() {
        val signature = Signature(byteArrayOf(1, 2, 3))
        val packageInfo = info(70)
        if (android.os.Build.VERSION.SDK_INT >= 28) {
            packageInfo.signingInfo = org.robolectric.util.ReflectionHelpers.callConstructor(SigningInfo::class.java)
            Shadows.shadowOf(packageInfo.signingInfo).setSignatures(arrayOf(signature))
        } else {
            packageInfo.signatures = arrayOf(signature)
        }
        assertEquals(setOf("039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81"),
            ApkUpdateBridge.certificates(packageInfo))
    }

    @Test fun checksPerApplicationInstallPermission() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val bridge = ApkUpdateBridge(activity)
        val result = Result()
        for (allowed in listOf(false, true)) {
            Shadows.shadowOf(activity.packageManager).setCanRequestPackageInstalls(allowed)
            bridge.onMethodCall(MethodCall("canInstall", null), result)
            assertEquals(android.os.Build.VERSION.SDK_INT < 26 || allowed, result.value)
        }
        bridge.dispose()
    }

    @Test fun missingPermissionSettingsReturnsActionableFailure() {
        if (android.os.Build.VERSION.SDK_INT < 26) return
        val activity = Robolectric.buildActivity(NoSettingsActivity::class.java).setup().get()
        val bridge = ApkUpdateBridge(activity)
        val result = Result()
        bridge.onMethodCall(MethodCall("openSettings", mapOf("language" to "en")), result)
        org.robolectric.shadows.ShadowAlertDialog.getLatestAlertDialog()
            .getButton(android.content.DialogInterface.BUTTON_POSITIVE).performClick()
        Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        assertEquals("no_installer", result.value)
        bridge.dispose()
    }
}

