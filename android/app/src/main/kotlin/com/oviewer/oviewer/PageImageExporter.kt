package com.oviewer.oviewer

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService

class PageImageExporter(
    private val activity: Activity,
    private val executor: Executor = Executors.newSingleThreadExecutor(),
    private val scan: ((File, String, (Boolean) -> Unit) -> Unit)? = null
) : MethodChannel.MethodCallHandler {
    private var pending: MethodChannel.Result? = null
    private var operation: (() -> Unit)? = null
    companion object { const val PERMISSION_REQUEST = 7314 }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "saveImage") { result.notImplemented(); return }
        if (pending != null) { result.success("busy"); return }
        val path = call.argument<String>("path")
        val name = call.argument<String>("name")
        val mime = call.argument<String>("mime")
        if (path == null || name == null || mime == null ||
            !name.matches(Regex("OViewer_[0-9]+_p[0-9]+_[0-9]+\\.(jpg|png|gif|webp)"))) {
            result.success("save_failed"); return
        }
        val source = File(path).canonicalFile
        if (!source.path.startsWith(activity.cacheDir.canonicalPath + File.separator) || !source.isFile) {
            result.success("save_failed"); return
        }
        if (mime !in listOf("image/jpeg", "image/png", "image/gif", "image/webp")) {
            result.success("unsupported_format"); return
        }
        pending = result
        operation = { executor.execute { save(source, name, mime) } }
        if (Build.VERSION.SDK_INT in 23..28 && activity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), PERMISSION_REQUEST)
        } else { operation?.invoke(); operation = null }
    }

    fun permissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) operation?.invoke()
        else finish("permission_denied")
        operation = null
        return true
    }

    private fun save(source: File, name: String, mime: String) {
        var uri: Uri? = null
        var legacy: File? = null
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                val resolver = activity.contentResolver
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.DISPLAY_NAME, name)
                    put(MediaStore.Images.Media.MIME_TYPE, mime)
                    put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/OViewer")
                    put(MediaStore.Images.Media.IS_PENDING, 1)
                }
                uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
                    ?: throw IllegalStateException("Insert failed")
                resolver.openOutputStream(uri)?.use { output -> source.inputStream().use { it.copyTo(output) } }
                    ?: throw IllegalStateException("Open failed")
                if (resolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null) != 1) {
                    throw IllegalStateException("Publish failed")
                }
                finish("saved")
            } else {
                val directory = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "OViewer")
                if (!directory.exists() && !directory.mkdirs()) throw IllegalStateException("Create directory failed")
                val destination = File(directory, name)
                if (!destination.createNewFile()) throw IllegalStateException("File exists")
                legacy = destination
                source.inputStream().use { input -> destination.outputStream().use { input.copyTo(it) } }
                val scanned: (Boolean) -> Unit = { success ->
                    if (!success) { destination.delete(); finish("save_failed") } else finish("saved")
                }
                if (scan != null) scan.invoke(destination, mime, scanned)
                else MediaScannerConnection.scanFile(activity, arrayOf(destination.path), arrayOf(mime)) { _, uri -> scanned(uri != null) }
            }
        } catch (_: SecurityException) {
            uri?.let { runCatching { activity.contentResolver.delete(it, null, null) } }
            legacy?.delete()
            finish("permission_denied")
        } catch (_: Exception) {
            uri?.let { runCatching { activity.contentResolver.delete(it, null, null) } }
            legacy?.delete()
            finish("save_failed")
        }
    }

    private fun finish(status: String) = activity.runOnUiThread {
        pending?.success(status)
        pending = null
    }

    fun dispose() {
        if (operation != null) { operation = null; finish("cancelled") }
        (executor as? ExecutorService)?.shutdown()
    }
}
