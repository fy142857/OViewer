package com.oviewer.oviewer

import android.app.ActivityManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.graphics.drawable.BitmapDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FilterOutputStream
import java.io.OutputStream
import java.util.UUID
import java.nio.channels.FileChannel
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Explicit conversion creates a new PNG. It never changes a selected source. */
class UploadImageConversion(private val context: Context,
    private val executor: Executor = Executors.newSingleThreadExecutor(),
    private val onActiveChanged: (Boolean) -> Unit = {}) : MethodChannel.MethodCallHandler {
    private val main = Handler(Looper.getMainLooper())
    private var busy = false
    private var disposed = false
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "convert") { result.notImplemented(); return }
        if (disposed) { result.error("disposed", "Image conversion is closed", null); return }
        if (busy) { result.error("busy", "An image conversion is already running", null); return }
        val path = call.argument<String>("relativePath")
        if (path == null) { result.error("unsafe_path", "Select an imported image", null); return }
        busy = true
        onActiveChanged(true)
        executor.execute {
            try {
                val converted = convert(path)
                main.post { busy = false; try { result.success(converted) } finally { onActiveChanged(false) } }
            } catch (error: Throwable) {
                val code = (error as? UploadTransferFailure)?.reason ?: if (error is OutOfMemoryError) "conversion_memory_limit" else "conversion_failed"
                main.post { busy = false; try { result.error(code, "The selected image could not be converted safely", null) } finally { onActiveChanged(false) } }
            }
        }
    }

    internal fun convert(relativePath: String): Map<String, Any> {
        val root = File(context.applicationInfo.dataDir, "app_flutter/uploads").apply { mkdirs() }
        if (!relativePath.startsWith("imports/")) throw UploadTransferFailure("unsafe_path")
        val source = UploadTransferPaths.file(root, relativePath)
        if (!source.isFile || source.length() > 100_000_000L) throw UploadTransferFailure("invalid_image")
        val memory = (context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).memoryClass.toLong() * 1024 * 1024
        val maxPixels = minOf(24_000_000L, memory / 12)
        val header = source.inputStream().use { input -> ByteArray(64).let { b -> b.copyOf(input.read(b).coerceAtLeast(0)) } }
        if (header.size >= 12 && String(header, 4, 4, Charsets.US_ASCII) == "ftyp") {
            val brands = String(header, Charsets.US_ASCII)
            if (listOf("msf1", "hevc", "hevx", "avis").any { brands.contains(it) }) {
                throw UploadTransferFailure("animated_conversion_unsupported")
            }
        }
        var expectedWidth = 0
        var expectedHeight = 0
        val bitmap: Bitmap = if (Build.VERSION.SDK_INT >= 28) {
            // A read-only mapping avoids materializing the whole encoded image
            // and does not depend on an Android-only file-descriptor decoder.
            val mapped = FileInputStream(source).channel.use {
                it.map(FileChannel.MapMode.READ_ONLY, 0, source.length())
            }
            val drawable = ImageDecoder.decodeDrawable(ImageDecoder.createSource(mapped)) { decoder, info, _ ->
                if (info.mimeType !in setOf("image/heif", "image/heic", "image/avif", "image/bmp", "image/x-ms-bmp", "image/x-icon", "image/vnd.wap.wbmp")) {
                    throw UploadTransferFailure("unsupported_conversion")
                }
                validateDimensions(info.size.width, info.size.height, maxPixels)
                expectedWidth = info.size.width; expectedHeight = info.size.height
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                decoder.setOnPartialImageListener { false }
            }
            (drawable as? BitmapDrawable)?.bitmap ?: throw UploadTransferFailure("animated_conversion_unsupported")
        } else {
            // Older decoders cannot reliably interpret HEIF or its orientation.
            if (header.size < 2 || header[0] != 'B'.code.toByte() || header[1] != 'M'.code.toByte()) {
                throw UploadTransferFailure("unsupported_conversion")
            }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(source.path, bounds)
            validateDimensions(bounds.outWidth, bounds.outHeight, maxPixels)
            expectedWidth = bounds.outWidth; expectedHeight = bounds.outHeight
            BitmapFactory.decodeFile(source.path, BitmapFactory.Options().apply { inPreferredConfig = Bitmap.Config.ARGB_8888 })
                ?: throw UploadTransferFailure("invalid_image")
        }
        val group = UUID.randomUUID().toString()
        val directory = UploadTransferPaths.file(root, "imports/$group")
        val partial = UploadTransferPaths.file(root, "imports/$group/converted.png.part")
        val output = UploadTransferPaths.file(root, "imports/$group/converted.png")
        var success = false
        var createdDirectory = false
        try {
            if (bitmap.width != expectedWidth || bitmap.height != expectedHeight) throw UploadTransferFailure("conversion_dimensions_changed")
            if (StatFs(root.path).availableBytes < 50_000_000L + 32 * 1024 * 1024) throw UploadTransferFailure("insufficient_storage")
            if (!directory.mkdirs()) throw UploadTransferFailure("storage")
            createdDirectory = true
            partial.outputStream().use { file ->
                val bounded = LimitedOutput(file)
                if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, bounded)) throw UploadTransferFailure("conversion_failed")
                file.fd.sync()
            }
            if (!partial.renameTo(output)) throw UploadTransferFailure("storage")
            success = true
            return mapOf("relativePath" to "imports/$group/converted.png", "displayName" to "converted.png",
                "size" to output.length(), "mimeType" to "image/png")
        } finally {
            bitmap.recycle()
            if (!success && createdDirectory) { partial.delete(); output.delete(); directory.delete() }
        }
    }

    fun dispose() { disposed = true; (executor as? ExecutorService)?.shutdown() }

    private fun validateDimensions(width: Int, height: Int, maxPixels: Long) {
        if (width !in 100..20000 || height !in 100..20000) throw UploadTransferFailure("image_dimensions")
        if (width.toLong() * height > maxPixels) throw UploadTransferFailure("conversion_memory_limit")
    }
    private class LimitedOutput(out: OutputStream) : FilterOutputStream(out) {
        private var bytes = 0L
        override fun write(value: Int) { checkLimit(1); out.write(value) }
        override fun write(data: ByteArray, offset: Int, length: Int) { checkLimit(length); out.write(data, offset, length) }
        private fun checkLimit(length: Int) {
            if (bytes + length > 50_000_000L) throw UploadTransferFailure("image_too_large")
            bytes += length
        }
    }
}
