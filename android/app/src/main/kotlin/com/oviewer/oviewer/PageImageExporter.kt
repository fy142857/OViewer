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
    private val allowConcurrent: Boolean = false,
    private val permissionRequest: Int = PERMISSION_REQUEST,
    private val namePattern: Regex = Regex("OViewer_[0-9]+_p[0-9]+_[0-9]+\\.(jpg|png|gif|webp)"),
    private val onSaved: ((String) -> Unit)? = null,
    private val scan: ((File, String, (Boolean) -> Unit) -> Unit)? = null
) : MethodChannel.MethodCallHandler {
    private data class Job(val source: File, val name: String, val mime: String, val result: MethodChannel.Result, val successMessage: String?)
    private val pending = mutableSetOf<Job>()
    private val waitingPermission = mutableListOf<Job>()
    private var disposed = false
    companion object { const val PERMISSION_REQUEST = 7314 }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "saveImage") { result.notImplemented(); return }
        if (disposed) { result.success("cancelled"); return }
        if (!allowConcurrent && pending.isNotEmpty()) { result.success("busy"); return }
        val path = call.argument<String>("path")
        val name = call.argument<String>("name")
        val mime = call.argument<String>("mime")
        if (path == null || name == null || mime == null || !name.matches(namePattern)) {
            result.success("save_failed"); return
        }
        val source = runCatching { File(path).canonicalFile }.getOrNull()
        if (source == null || !source.path.startsWith(activity.cacheDir.canonicalPath + File.separator) || !source.isFile) {
            result.success("save_failed"); return
        }
        if (mime !in listOf("image/jpeg", "image/png", "image/gif", "image/webp")) {
            result.success("unsupported_format"); return
        }
        val job = Job(source, name, mime, result, call.argument<String>("successMessage"))
        pending.add(job)
        if (Build.VERSION.SDK_INT in 23..28 && activity.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
            waitingPermission.add(job)
            if (waitingPermission.size == 1) {
                try { activity.requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE), permissionRequest) }
                catch (_: Exception) { waitingPermission.remove(job); finish(job, "permission_denied") }
            }
        } else { execute(job) }
    }

    fun permissionResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != permissionRequest) return false
        val jobs = waitingPermission.toList()
        waitingPermission.clear()
        jobs.forEach { job ->
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) execute(job)
            else finish(job, "permission_denied")
        }
        return true
    }

    private fun execute(job: Job) {
        try { executor.execute { save(job) } }
        catch (_: Exception) { finish(job, "save_failed") }
    }

    private fun save(job: Job) {
        val (source, name, mime) = job
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
                finish(job, "saved")
            } else {
                val directory = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "OViewer")
                if (!directory.exists() && !directory.mkdirs()) throw IllegalStateException("Create directory failed")
                val destination = File(directory, name)
                if (!destination.createNewFile()) throw IllegalStateException("File exists")
                legacy = destination
                source.inputStream().use { input -> destination.outputStream().use { input.copyTo(it) } }
                val scanned: (Boolean) -> Unit = { success ->
                    if (!success) { destination.delete(); finish(job, "save_failed") } else finish(job, "saved")
                }
                if (scan != null) scan.invoke(destination, mime, scanned)
                else MediaScannerConnection.scanFile(activity, arrayOf(destination.path), arrayOf(mime)) { _, uri -> scanned(uri != null) }
            }
        } catch (_: SecurityException) {
            uri?.let { runCatching { activity.contentResolver.delete(it, null, null) } }
            legacy?.delete()
            finish(job, "permission_denied")
        } catch (_: Exception) {
            uri?.let { runCatching { activity.contentResolver.delete(it, null, null) } }
            legacy?.delete()
            finish(job, "save_failed")
        }
    }

    private fun finish(job: Job, status: String) = activity.runOnUiThread {
        if (pending.remove(job)) {
            if (status == "saved") job.successMessage?.let { message ->
                runCatching { onSaved?.invoke(message) }.onFailure {
                    android.util.Log.w("OViewerSaveFeedback", "Saved-image feedback failed", it)
                }
            }
            job.result.success(status)
        }
    }

    fun dispose() {
        disposed = true
        val jobs = waitingPermission.toList()
        waitingPermission.clear()
        jobs.forEach { finish(it, "cancelled") }
        (executor as? ExecutorService)?.shutdown()
    }
}
