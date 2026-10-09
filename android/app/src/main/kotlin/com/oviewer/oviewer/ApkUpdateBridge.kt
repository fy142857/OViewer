package com.oviewer.oviewer

import android.app.Activity
import android.app.AlertDialog
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

class UpdateFileProvider : FileProvider()

class ApkUpdateBridge(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private val worker = Executors.newSingleThreadExecutor()
    private var disposed = false
    private var permissionDialog: AlertDialog? = null

    private class Failure(val code: String) : Exception(code)

    companion object {
        internal fun packageFile(cacheDir: File, path: String): File {
            val root = File(cacheDir, "updates").canonicalFile
            val file = File(path).canonicalFile
            require(file.parentFile == root && file.name == "package.apk" && file.isFile) { "invalid_path" }
            return file
        }

        @Suppress("DEPRECATION")
        internal fun buildNumber(info: PackageInfo): Long =
            if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

        @Suppress("DEPRECATION")
        internal fun certificates(info: PackageInfo): Set<String> {
            val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners
                else info.signatures
            return signatures?.map { signature ->
                MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                    .joinToString("") { "%02x".format(it.toInt() and 0xff) }
            }?.toSet() ?: emptySet()
        }

        internal fun validate(info: PackageInfo, installed: PackageInfo,
                              version: String, number: Long, expectedCertificate: String,
                              archiveCertificates: Set<String> = certificates(info),
                              installedCertificates: Set<String> = certificates(installed)) {
            if (info.packageName != "com.oviewer.oviewer" || info.packageName != installed.packageName)
                throw Failure("package_mismatch")
            if (info.versionName != version || buildNumber(info) != number) throw Failure("version_mismatch")
            if (number <= buildNumber(installed)) throw Failure("not_newer")
            if (!Regex("[0-9a-f]{64}").matches(expectedCertificate) ||
                archiveCertificates != setOf(expectedCertificate) || archiveCertificates != installedCertificates)
                throw Failure("signature_mismatch")
        }

        internal fun installIntent(activity: Activity, file: File): Intent {
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.apk_updates", file)
            return Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                clipData = ClipData.newRawUri("OViewer update", uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
        }
    }

    private fun allowed() = Build.VERSION.SDK_INT < 26 || activity.packageManager.canRequestPackageInstalls()

    @Suppress("DEPRECATION")
    private fun inspect(call: MethodCall): File {
        val path = call.argument<String>("path") ?: throw Failure("invalid_path")
        val file = try { packageFile(activity.cacheDir, path) } catch (_: Exception) { throw Failure("invalid_path") }
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val archive = activity.packageManager.getPackageArchiveInfo(file.path, flags) ?: throw Failure("invalid_apk")
        val installed = activity.packageManager.getPackageInfo(activity.packageName, flags)
        validate(archive, installed,
            call.argument<String>("version") ?: throw Failure("version_mismatch"),
            call.argument<Number>("buildNumber")?.toLong() ?: throw Failure("version_mismatch"),
            call.argument<String>("certificate") ?: throw Failure("signature_mismatch"))
        return file
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "canInstall" -> result.success(allowed())
            "openSettings" -> explainPermission(call, result)
            "inspect", "install" -> worker.execute {
                try {
                    val file = inspect(call)
                    activity.runOnUiThread {
                        if (disposed || activity.isFinishing) { result.error("unavailable", null, null); return@runOnUiThread }
                        try {
                            if (call.method == "install") {
                                if (!allowed()) throw Failure("permission")
                                activity.startActivity(installIntent(activity, file))
                            }
                            result.success(null)
                        } catch (error: Exception) { fail(result, error) }
                    }
                } catch (error: Exception) { activity.runOnUiThread { fail(result, error) } }
            }
            else -> result.notImplemented()
        }
    }

    private fun explainPermission(call: MethodCall, result: MethodChannel.Result) {
        if (disposed || activity.isFinishing || permissionDialog != null) {
            result.error("unavailable", null, null); return
        }
        if (Build.VERSION.SDK_INT < 26) { result.success(false); return }
        val chinese = call.argument<String>("language") != "en"
        var answered = false
        fun finish(value: Boolean) { if (!answered) { answered = true; result.success(value) } }
        permissionDialog = AlertDialog.Builder(activity)
            .setTitle(if (chinese) "允许安装更新" else "Allow update installation")
            .setMessage(if (chinese) "请在系统设置中允许 OViewer 安装未知应用，然后返回继续安装。" else "Allow OViewer to install unknown apps in system settings, then return to continue.")
            .setNegativeButton(if (chinese) "取消" else "Cancel") { _, _ -> finish(false) }
            .setPositiveButton(if (chinese) "前往设置" else "Open settings") { _, _ ->
                try {
                    activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:${activity.packageName}")))
                    finish(true)
                } catch (error: Exception) {
                    if (!answered) { answered = true; fail(result, error) }
                }
            }.create().also { dialog ->
                dialog.setOnDismissListener { permissionDialog = null; finish(false) }
                dialog.show()
            }
    }

    private fun fail(result: MethodChannel.Result, error: Exception) =
        result.error(when (error) {
            is Failure -> error.code
            is ActivityNotFoundException -> "no_installer"
            is SecurityException -> "permission"
            else -> "invalid_apk"
        }, null, null)

    fun dispose() {
        disposed = true
        permissionDialog?.dismiss()
        worker.shutdown()
    }
}
