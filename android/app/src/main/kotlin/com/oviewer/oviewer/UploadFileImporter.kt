package com.oviewer.oviewer

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Build
import android.os.Looper
import android.os.StatFs
import android.provider.OpenableColumns
import android.provider.MediaStore
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.InputStream
import java.lang.ref.WeakReference
import java.util.UUID
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Imports only user-selected documents. The caller never chooses a filesystem root. */
class UploadFileImporter(
    context: Context,
    private val executor: Executor = Executors.newSingleThreadExecutor(),
    private val onActiveChanged: (Boolean) -> Unit = {},
) : MethodChannel.MethodCallHandler {
    private val app = context.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private var activity = WeakReference<Activity>(null)
    private var pending: ImportJob? = null
        set(value) {
            val changed = (field == null) != (value == null)
            field = value
            if (changed) onActiveChanged(value != null)
        }
    private var disposed = false
    private var nextRequestCode = REQUEST_CODE

    private class ImportJob(val result: MethodChannel.Result, val requestCode: Int) {
        val id = UUID.randomUUID().toString()
        val cancelled = AtomicBoolean(false)
        var copying = false // Accessed only on the platform thread.
        var finishing = false
        @Volatile var input: InputStream? = null
    }

    companion object {
        const val REQUEST_CODE = 7843
        private const val LAST_REQUEST_CODE = 9842
        private const val MAX_FILES = 2000
        private const val MAX_IMPORT_BYTES = 10_000_000_000L
        private const val SPACE_RESERVE = 32L * 1024 * 1024
    }

    fun attach(host: Activity) { activity = WeakReference(host) }
    fun detach(host: Activity) { if (activity.get() === host) activity.clear() }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) { result.error("disposed", "The file importer is closed.", null); return }
        // Even ignored path arguments can hide an integration mistake. Reject them.
        val args = call.arguments as? Map<*, *>
        if (args?.containsKey("root") == true || args?.containsKey("path") == true) {
            result.error("invalid_arguments", "Upload storage is selected by the application.", null)
            return
        }
        when (call.method) {
            "pickFiles" -> pick(false, result)
            "pickPhotos" -> pick(true, result)
            "cancelImport" -> { cancel(); result.success(null) }
            "availableBytes" -> try {
                result.success(StatFs(uploadRoot().path).availableBytes)
            } catch (_: Exception) { result.error("storage", "Storage is unavailable.", null) }
            // Android exclusions are declared in both backup XML files by the host app.
            "excludeFromBackup" -> try { uploadRoot(); result.success(true) }
                catch (_: Exception) { result.error("storage", "Upload storage is unavailable.", null) }
            else -> result.notImplemented()
        }
    }

    private fun pick(photosOnly: Boolean, result: MethodChannel.Result) {
        if (pending != null) { result.error("busy", "A file selection is already active.", null); return }
        val host = activity.get()
        if (host == null || host.isFinishing || host.isDestroyed) {
            result.error("no_activity", "Open the upload page before choosing files.", null); return
        }
        val job = ImportJob(result, nextRequestCode)
        nextRequestCode = if (nextRequestCode == LAST_REQUEST_CODE) REQUEST_CODE else nextRequestCode + 1
        pending = job
        val documentsIntent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (photosOnly) "image/*" else "*/*"
            if (!photosOnly) putExtra(Intent.EXTRA_MIME_TYPES,
                arrayOf("image/*", "application/zip", "application/x-zip-compressed"))
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val intent = if (photosOnly && Build.VERSION.SDK_INT >= 33) {
            Intent(MediaStore.ACTION_PICK_IMAGES).apply {
                type = "image/*"
                putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, minOf(MAX_FILES, MediaStore.getPickImagesMaxLimit()))
            }
        } else documentsIntent
        try { host.startActivityForResult(intent, job.requestCode) }
        catch (_: android.content.ActivityNotFoundException) {
            try { host.startActivityForResult(documentsIntent, job.requestCode) }
            catch (_: Exception) {
                pending = null
                result.error("picker_unavailable", "No document picker is available.", null)
            }
        }
        catch (_: Exception) {
            pending = null
            result.error("picker_unavailable", "No document picker is available.", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode !in REQUEST_CODE..LAST_REQUEST_CODE) return false
        val job = pending ?: return true
        if (requestCode != job.requestCode) return true
        if (job.copying) return true // Ignore duplicate activity callbacks.
        if (resultCode != Activity.RESULT_OK || job.cancelled.get()) {
            finish(job, emptyList(), emptyList(), cancelled = true)
            return true
        }
        val uris = mutableListOf<Uri>()
        val clip = data?.clipData
        if (clip != null) {
            if (clip.itemCount > MAX_FILES) {
                finish(job, emptyList(), listOf(error("", "too_many_files")))
                return true
            }
            for (index in 0 until clip.itemCount) uris.add(clip.getItemAt(index).uri)
        } else data?.data?.let { uris.add(it) }
        if (uris.isEmpty()) {
            finish(job, emptyList(), emptyList(), cancelled = true)
            return true
        }
        job.copying = true
        try { executor.execute { copy(job, uris) } }
        catch (_: Exception) { finish(job, emptyList(), listOf(error("", "import_failed"))) }
        return true
    }

    private fun copy(job: ImportJob, uris: List<Uri>) {
        val files = mutableListOf<Map<String, Any>>()
        val errors = mutableListOf<Map<String, String>>()
        var directory: File? = null
        var total = 0L
        try {
            val root = uploadRoot()
            directory = File(root, "imports/${job.id}").canonicalFile
            check(directory.path.startsWith(root.canonicalPath + File.separator))
            check(directory.mkdirs())
            for ((index, uri) in uris.withIndex()) {
                if (job.cancelled.get()) break
                var name = ""
                var partial: File? = null
                try {
                    if (uri.scheme != "content") throw ImportFailure("unsupported_uri")
                    var expectedSize: Long? = null
                    app.contentResolver.query(uri,
                        arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                            if (nameIndex >= 0) name = cursor.getString(nameIndex)?.take(512) ?: ""
                            val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                            if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) expectedSize = cursor.getLong(sizeIndex)
                        }
                    }
                    if (expectedSize != null && expectedSize!! > MAX_IMPORT_BYTES - total)
                        throw ImportFailure("selection_too_large")
                    val available = StatFs(directory.path).availableBytes
                    if (available < SPACE_RESERVE || (expectedSize ?: 0L) > available - SPACE_RESERVE)
                        throw ImportFailure("insufficient_storage")
                    val suffix = name.substringAfterLast('.', "bin").lowercase()
                        .takeIf { it.matches(Regex("[a-z0-9]{1,12}")) } ?: "bin"
                    val destination = File(directory, "${UUID.randomUUID()}.$suffix")
                    val staging = File(directory, destination.name + ".part")
                    partial = staging
                    val mime = app.contentResolver.getType(uri) ?: "application/octet-stream"
                    var size = 0L
                    val input = app.contentResolver.openInputStream(uri) ?: throw ImportFailure("read_failed")
                    job.input = input
                    input.use { source ->
                        staging.outputStream().use { output ->
                            val buffer = ByteArray(64 * 1024)
                            while (true) {
                                if (job.cancelled.get()) throw ImportFailure("cancelled")
                                val count = source.read(buffer)
                                if (count < 0) break
                                if (count == 0) continue
                                if (size + count > MAX_IMPORT_BYTES - total) throw ImportFailure("selection_too_large")
                                if (StatFs(directory.path).availableBytes < SPACE_RESERVE + count)
                                    throw ImportFailure("insufficient_storage")
                                output.write(buffer, 0, count)
                                size += count
                            }
                            output.fd.sync()
                        }
                    }
                    job.input = null
                    if (job.cancelled.get()) throw ImportFailure("cancelled")
                    if (!staging.renameTo(destination)) throw ImportFailure("write_failed")
                    partial = null
                    total += size
                    files.add(mapOf("relativePath" to "imports/${job.id}/${destination.name}",
                        "displayName" to name.ifEmpty { destination.name }, "size" to size, "mimeType" to mime))
                } catch (failure: Exception) {
                    job.input = null
                    partial?.delete()
                    if (job.cancelled.get()) break
                    val reason = when (failure) {
                        is ImportFailure -> failure.reason
                        is SecurityException -> "permission_denied"
                        else -> "read_failed"
                    }
                    errors.add(error(name, reason))
                    if (reason == "insufficient_storage" || reason == "selection_too_large") {
                        for (remaining in index + 1 until uris.size) errors.add(error("", "not_imported_$reason"))
                        break
                    }
                }
            }
        } catch (_: Exception) { errors.add(error("", "storage")) }
        if (job.cancelled.get()) {
            // Only our generated, flat session directory is ever cleaned here.
            directory?.listFiles()?.forEach { if (it.isFile) it.delete() }
            directory?.delete()
            finish(job, emptyList(), emptyList(), cancelled = true)
        } else {
            if (files.isEmpty()) directory?.delete()
            finish(job, files, errors)
        }
    }

    private fun uploadRoot(): File {
        val documents = app.getDir("flutter", Context.MODE_PRIVATE).canonicalFile
        val root = File(documents, "uploads").canonicalFile
        check(root.path == documents.path + File.separator + "uploads")
        check(root.exists() || root.mkdirs())
        return root
    }

    private fun cancel() {
        val job = pending ?: return
        job.cancelled.set(true)
        try { job.input?.close() } catch (_: Exception) { /* Copy completion reports cancellation. */ }
        if (!job.copying) {
            try { activity.get()?.finishActivity(job.requestCode) } catch (_: Exception) { }
            finish(job, emptyList(), emptyList(), cancelled = true)
        }
    }

    private fun finish(job: ImportJob, files: List<Map<String, Any>>, errors: List<Map<String, String>>,
                       cancelled: Boolean = false) {
        val action = {
            if (pending === job && !job.finishing) {
                job.finishing = true
                if (job.cancelled.get() && files.isNotEmpty()) {
                    // Cancellation may arrive after copy completion but before its platform callback.
                    executor.execute {
                        runCatching {
                            val root = uploadRoot()
                            val directory = File(root, "imports/${job.id}").canonicalFile
                            check(directory.path.startsWith(root.canonicalPath + File.separator))
                            directory.listFiles()?.forEach { if (it.isFile) it.delete() }
                            directory.delete()
                        }
                        main.post {
                            if (pending === job) {
                                pending = null
                                job.result.success(mapOf("cancelled" to true, "files" to emptyList<Any>(), "errors" to emptyList<Any>()))
                                closeIfDisposed()
                            }
                        }
                    }
                } else {
                    pending = null
                    job.result.success(mapOf("cancelled" to (cancelled || job.cancelled.get()), "files" to files, "errors" to errors))
                    closeIfDisposed()
                }
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) action() else main.post(action)
    }

    fun dispose() {
        disposed = true
        cancel()
        activity.clear()
        closeIfDisposed()
    }

    private fun closeIfDisposed() { if (disposed && pending == null) (executor as? ExecutorService)?.shutdown() }

    private fun error(name: String, reason: String) = mapOf("displayName" to name, "reason" to reason)
    private class ImportFailure(val reason: String) : Exception()
}
