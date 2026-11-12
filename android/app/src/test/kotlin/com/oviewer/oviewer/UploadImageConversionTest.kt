package com.oviewer.oviewer

import android.app.Application
import android.graphics.BitmapFactory
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowStatFs
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executor

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [21, 28, 35], application = Application::class)
class UploadImageConversionTest {
    private fun bmp(width: Int = 120, height: Int = 160): ByteArray {
        val stride = (width * 3 + 3) / 4 * 4
        return ByteBuffer.allocate(54 + stride * height).order(ByteOrder.LITTLE_ENDIAN).apply {
            put('B'.code.toByte()); put('M'.code.toByte()); putInt(capacity()); putInt(0); putInt(54)
            putInt(40); putInt(width); putInt(height); putShort(1); putShort(24)
            putInt(0); putInt(stride * height); putInt(0); putInt(0); putInt(0); putInt(0)
            repeat(height) { repeat(width) { put(32); put(80); put(160.toByte()) }; repeat(stride - width * 3) { put(0) } }
        }.array()
    }
    private fun root() = File(RuntimeEnvironment.getApplication().applicationInfo.dataDir,
        "app_flutter/uploads").apply {
            mkdirs()
            ShadowStatFs.registerStats(canonicalPath, 10_000_000, 9_000_000, 8_000_000)
            ShadowStatFs.registerStats(path, 10_000_000, 9_000_000, 8_000_000)
        }
    private fun converter() = UploadImageConversion(RuntimeEnvironment.getApplication(), Executor { it.run() })

    @Test @Config(sdk = [21])
    fun legacyBmpConversionKeepsDimensionsAndOriginalBytes() = checkBmpConversion()

    @Test @Config(sdk = [28, 35]) @GraphicsMode(GraphicsMode.Mode.NATIVE)
    fun modernBmpConversionKeepsDimensionsAndOriginalBytes() = checkBmpConversion()

    private fun checkBmpConversion() {
        val root = root()
        val directory = File(root, "imports/original").apply { mkdirs() }
        val source = File(directory, "drawing.bmp").apply { writeBytes(bmp()) }
        val before = source.readBytes()
        val converted = converter().convert("imports/original/drawing.bmp")
        val output = File(root, converted["relativePath"] as String)
        assertTrue(output.isFile)
        assertTrue(output.name.endsWith(".png"))
        assertArrayEquals(before, source.readBytes())
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(output.path, bounds)
        assertEquals(120, bounds.outWidth); assertEquals(160, bounds.outHeight)
    }

    @Test fun rejectsTraversalAndNonImportedFilesWithoutTouchingThem() {
        val source = File(root(), "secret.bmp").apply { writeBytes(bmp()) }
        for (path in listOf("../secret.bmp", "imports/../../secret.bmp", "secret.bmp")) {
            try { converter().convert(path); fail("Expected unsafe path") }
            catch (error: UploadTransferFailure) { assertEquals("unsafe_path", error.reason) }
        }
        assertTrue(source.exists())
    }

    @Test fun invalidOrAnimatedSourcesDoNotCreateConvertedCopies() {
        val directory = File(root(), "imports/original").apply { mkdirs() }
        File(directory, "invalid.heic").writeText("not an image")
        try { converter().convert("imports/original/invalid.heic"); fail("Expected invalid image") }
        catch (_: Exception) { /* Unsupported decoder/input is expected. */ }
        assertTrue(File(directory, "invalid.heic").exists())
        assertFalse(root().walkTopDown().any { it.name == "converted.png" })
    }
}
